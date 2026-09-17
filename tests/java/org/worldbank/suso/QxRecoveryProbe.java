import java.net.*;
import java.nio.file.*;
import java.lang.reflect.*;
import java.util.*;

public final class QxRecoveryProbe {
    static Method method(Class<?> c,String n,Class<?>... p) throws Exception {
        Method m=c.getDeclaredMethod(n,p);m.setAccessible(true);return m;
    }
    public static void main(String[] args) throws Exception {
        Class<?> before=new URLClassLoader(new URL[]{Path.of(args[0]).toUri().toURL()},null).loadClass("org.worldbank.suso.Qx");
        Class<?> after=new URLClassLoader(new URL[]{Path.of(args[1]).toUri().toURL()},null).loadClass("org.worldbank.suso.Qx");
        Method oldParse=method(before,"parse",Path.class),newParse=method(after,"parse",Path.class);
        for(int i=2;i<args.length;i++) {
            Object a=oldParse.invoke(null,Path.of(args[i])), b=newParse.invoke(null,Path.of(args[i]));
            if(!a.equals(b)) throw new AssertionError("metadata changed: "+args[i]+"\n"+a+"\n"+b);
        }
        Method oldTri=method(before,"triExpression",String.class,String.class),newTri=method(after,"triExpression",String.class,String.class);
        String[] atoms={"a==1","b!=2","IsAnswered(c)","!IsAnswered(a)","self>0","x.Contains(7)","true","false","x","new[]{1}.Contains(a)","x==\"yes\"","x + y > 10","(x==1)"};
        int n=0;
        for(String a:atoms)for(String b:atoms)for(String op:new String[]{"&&","||","&","|"}){
            String e="!("+a+") "+op+" ("+b+")";
            Object av=oldTri.invoke(null,e,"target"),bv=newTri.invoke(null,e,"target");
            if(!av.equals(bv))throw new AssertionError("expression changed: "+e+"\n"+av+"\n"+bv);
            n++;
        }
        Path large=Files.createTempFile("suso-large-options", ".html");
        StringBuilder html=new StringBuilder("<div class=\"question-container\"><div class=\"variable_name\">sector</div><div class=\"type\">Single option</div>");
        for(int i=1;i<=5000;i++)html.append("<div class=\"option-value\"><span>").append(i).append("</span><label>Category ").append(i).append(" &amp; detail</label></div>");
        Files.writeString(large,html.append("</div>").toString());
        List<?> rows=(List<?>)newParse.invoke(null,large);
        Map<?,?> row=(Map<?,?>)rows.get(0);
        if(!"5000".equals(row.get("qx_nopts")))throw new AssertionError("option count");
        String values=(String)row.get("qx_optvals");
        if(values.split(" ").length!=5000 || !values.endsWith(" 5000"))throw new AssertionError("allowed values incomplete");
        if(!((String)row.get("qx_optmap")).endsWith("5000\u001eCategory 5000 & detail"))throw new AssertionError("labels incomplete");
        Files.delete(large);
        System.out.println("PASS: "+(args.length-2)+" questionnaire fixtures unchanged; "+n+" expression cases identical; 5000 categories and labels complete.");
    }
}
